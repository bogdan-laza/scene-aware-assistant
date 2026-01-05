import { ComponentFixture, TestBed } from '@angular/core/testing';

import { OptionSelector } from './option-selector';

describe('OptionSelector', () => {
  let component: OptionSelector;
  let fixture: ComponentFixture<OptionSelector>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [OptionSelector]
    })
    .compileComponents();

    fixture = TestBed.createComponent(OptionSelector);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});

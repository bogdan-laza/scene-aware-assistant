import { Component, computed, contentChildren, input, signal } from '@angular/core';

@Component({
  selector: 'app-option',
  template: `<div class="option"><ng-content></ng-content></div>`,
  styles: [`
    .option { padding: 5px; cursor: pointer; }
    .option:hover { background: #eee; }
  `],
  standalone: false
})

export class OptionComponent {
  value = input.required<string>();
  label = input.required<string>();
}

